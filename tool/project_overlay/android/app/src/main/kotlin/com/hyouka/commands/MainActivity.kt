package com.hyouka.commands

import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.IBinder
import android.os.RemoteException
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.HashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.hyouka.commands/shizuku"
        private const val REQUEST_CODE = 4401
        private const val BACKUP_IMPORT_REQUEST_CODE = 4402
        private const val PREFERENCES_NAME = "commands_app_preferences"
        private const val MAX_BACKUP_BYTES = 512 * 1024
        private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
    }

    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val pendingActions = ArrayDeque<Runnable>()

    private var userService: ICommandService? = null
    private var binding = false
    private var pendingCommandResult: MethodChannel.Result? = null
    private var pendingCommand: String? = null
    private var pendingCommandId = -1L

    @Volatile
    private var activeCommandId = -1L

    private val pendingCancellations: MutableSet<Long> = ConcurrentHashMap.newKeySet()
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingBackupImportResult: MethodChannel.Result? = null

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == REQUEST_CODE) {
            val result = pendingPermissionResult
            if (result != null) {
                pendingPermissionResult = null
                runOnUiThread {
                    result.success(grantResult == PackageManager.PERMISSION_GRANTED)
                }
            }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            userService = ICommandService.Stub.asInterface(service)
            binding = false
            while (pendingActions.isNotEmpty()) {
                pendingActions.removeFirst().run()
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            userService = null
            binding = false
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result -> handleCall(call, result) }
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "requestPermission" -> requestPermission(result)
            "runCommand" -> {
                val commandId = call.argument<Number>("commandId")
                if (commandId == null) {
                    result.error("INVALID_COMMAND_ID", "Missing command ID.", null)
                } else {
                    runCommand(call.argument("command"), commandId.toLong(), result)
                }
            }
            "cancelCommand" -> {
                val commandId = call.argument<Number>("commandId")
                if (commandId == null) {
                    result.error("INVALID_COMMAND_ID", "Missing command ID.", null)
                } else {
                    cancelCommand(commandId.toLong(), result)
                }
            }
            "saveOutput" -> saveOutput(call.argument("content"), result)
            "loadPreferences" -> result.success(loadPreferences())
            "savePreferences" -> savePreferences(call, result)
            "exportBackup" -> exportBackup(call.argument("content"), result)
            "importBackup" -> importBackup(result)
            else -> result.notImplemented()
        }
    }

    private fun status(): Map<String, Any> {
        val installed = isInstalled()
        var running = false
        var permission = false

        try {
            running = Shizuku.pingBinder()
            if (running) {
                permission = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
            }
        } catch (_: Throwable) {
        }

        return hashMapOf(
            "installed" to installed,
            "running" to running,
            "permission" to permission,
            "serviceConnected" to (userService != null),
            "binding" to binding,
        )
    }

    private fun isInstalled(): Boolean {
        return try {
            packageManager.getApplicationInfo(SHIZUKU_PACKAGE, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun authorized(): Boolean {
        return try {
            Shizuku.pingBinder() &&
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        try {
            if (!isInstalled()) {
                result.error("SHIZUKU_NOT_INSTALLED", "Shizuku is not installed.", null)
                return
            }
            if (!Shizuku.pingBinder()) {
                result.error("SHIZUKU_NOT_RUNNING", "Shizuku is not running.", null)
                return
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                result.success(true)
                return
            }
            if (pendingPermissionResult != null) {
                result.error(
                    "PERMISSION_REQUEST_PENDING",
                    "A permission request is already pending.",
                    null,
                )
                return
            }
            pendingPermissionResult = result
            Shizuku.requestPermission(REQUEST_CODE)
        } catch (error: Throwable) {
            pendingPermissionResult = null
            result.error("SHIZUKU_PERMISSION_ERROR", messageOf(error), null)
        }
    }

    private fun runCommand(command: String?, commandId: Long, result: MethodChannel.Result) {
        if (command.isNullOrBlank()) {
            result.error("EMPTY_COMMAND", "Enter a shell command first.", null)
            return
        }
        if (commandId <= 0L) {
            result.error("INVALID_COMMAND_ID", "Invalid command ID.", null)
            return
        }
        if (pendingCommandResult != null || activeCommandId != -1L) {
            result.error("COMMAND_BUSY", "A command is already running.", null)
            return
        }
        if (!authorized()) {
            result.error(
                "SHIZUKU_PERMISSION_REQUIRED",
                "Shizuku is not installed, not running, or not authorized.",
                status(),
            )
            return
        }

        pendingCommand = command
        pendingCommandId = commandId
        pendingCommandResult = result

        if (userService != null) {
            executePending()
            return
        }
        if (binding) return

        binding = true
        pendingActions.add(Runnable { executePending() })

        try {
            val args = Shizuku.UserServiceArgs(
                ComponentName(packageName, CommandUserService::class.java.name),
            )
                .version(2)
                .tag("commands")
                .daemon(false)
                .processNameSuffix("commands")
            Shizuku.bindUserService(args, connection)
        } catch (error: Throwable) {
            binding = false
            pendingActions.clear()
            pendingCommandResult = null
            pendingCommand = null
            pendingCommandId = -1L
            pendingCancellations.remove(commandId)
            result.error("USER_SERVICE_BIND_ERROR", messageOf(error), null)
        }
    }

    private fun cancelCommand(commandId: Long, result: MethodChannel.Result) {
        if (commandId <= 0L) {
            result.error("INVALID_COMMAND_ID", "Invalid command ID.", null)
            return
        }
        if (pendingCommandResult != null && pendingCommandId == commandId) {
            pendingCancellations.add(commandId)
            result.success(true)
            return
        }
        if (activeCommandId != commandId) {
            result.success(false)
            return
        }

        val service = userService
        if (service == null) {
            pendingCancellations.add(commandId)
            result.success(true)
            return
        }

        executor.execute {
            try {
                val cancelled = service.cancel(commandId)
                runOnUiThread { result.success(cancelled) }
            } catch (error: RemoteException) {
                userService = null
                runOnUiThread {
                    result.error("USER_SERVICE_CANCEL_ERROR", messageOf(error), null)
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error("COMMAND_CANCEL_ERROR", messageOf(error), null)
                }
            }
        }
    }

    private fun executePending() {
        val service = userService
        val result = pendingCommandResult
        val command = pendingCommand
        val commandId = pendingCommandId

        pendingCommandResult = null
        pendingCommand = null
        pendingCommandId = -1L

        if (service == null || result == null || command == null || commandId <= 0L) return

        activeCommandId = commandId
        executor.execute {
            try {
                val output = HashMap<String, Any>()
                if (pendingCancellations.remove(commandId)) {
                    output["stdout"] = ""
                    output["stderr"] = ""
                    output["exitCode"] = -1
                    output["cancelled"] = true
                } else {
                    val bundle = service.execute(command, commandId)
                    output["stdout"] = bundle.getString("stdout", "")
                    output["stderr"] = bundle.getString("stderr", "")
                    output["exitCode"] = bundle.getInt("exitCode", -1)
                    output["cancelled"] = bundle.getBoolean("cancelled", false)
                }

                runOnUiThread {
                    if (activeCommandId == commandId) activeCommandId = -1L
                    result.success(output)
                }
            } catch (error: RemoteException) {
                userService = null
                runOnUiThread {
                    if (activeCommandId == commandId) activeCommandId = -1L
                    result.error("USER_SERVICE_EXECUTE_ERROR", messageOf(error), null)
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    if (activeCommandId == commandId) activeCommandId = -1L
                    result.error("COMMAND_PROCESS_ERROR", messageOf(error), null)
                }
            }
        }
    }

    private fun loadPreferences(): Map<String, Any> {
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        return hashMapOf(
            "themeMode" to (preferences.getString("themeMode", "dark") ?: "dark"),
            "fontScale" to preferences.getFloat("fontScale", 1.0f),
            "lastCommand" to (preferences.getString("lastCommand", "") ?: ""),
            "historyJson" to (preferences.getString("historyJson", "[]") ?: "[]"),
            "changesJson" to (preferences.getString("changesJson", "[]") ?: "[]"),
        )
    }

    private fun savePreferences(call: MethodCall, result: MethodChannel.Result) {
        val themeMode = call.argument<String>("themeMode")
        val fontScale = call.argument<Number>("fontScale")?.toFloat()
        val lastCommand = call.argument<String>("lastCommand")
        val historyJson = call.argument<String>("historyJson")
        val changesJson = call.argument<String>("changesJson")

        if (themeMode != "dark" && themeMode != "light" && themeMode != "system") {
            result.error("INVALID_PREFERENCES", "Unsupported appearance value.", null)
            return
        }
        if (fontScale == null || !fontScale.isFinite() || fontScale < 0.85f || fontScale > 1.4f) {
            result.error("INVALID_PREFERENCES", "Text scale is outside the supported range.", null)
            return
        }
        if (lastCommand == null || lastCommand.length > 4096 ||
            historyJson == null || historyJson.length > 300000 ||
            changesJson == null || changesJson.length > 100000
        ) {
            result.error("INVALID_PREFERENCES", "Preference data is too large or incomplete.", null)
            return
        }

        getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
            .edit()
            .putString("themeMode", themeMode)
            .putFloat("fontScale", fontScale)
            .putString("lastCommand", lastCommand)
            .putString("historyJson", historyJson)
            .putString("changesJson", changesJson)
            .apply()
        result.success(true)
    }

    private fun saveOutput(content: String?, result: MethodChannel.Result) {
        if (content == null) {
            result.error("SAVE_EMPTY", "There is no output to save.", null)
            return
        }
        saveTextToDownloads(content, "commands.txt", "text/plain", result, "SAVE_OUTPUT_ERROR")
    }

    private fun exportBackup(content: String?, result: MethodChannel.Result) {
        if (content.isNullOrEmpty()) {
            result.error("BACKUP_EMPTY", "There is no backup data to export.", null)
            return
        }
        if (content.toByteArray(StandardCharsets.UTF_8).size > MAX_BACKUP_BYTES) {
            result.error("BACKUP_TOO_LARGE", "Backup exceeds the supported size limit.", null)
            return
        }
        saveTextToDownloads(
            content,
            "commands-backup.json",
            "application/json",
            result,
            "EXPORT_BACKUP_ERROR",
        )
    }

    private fun saveTextToDownloads(
        content: String,
        filename: String,
        mimeType: String,
        result: MethodChannel.Result,
        errorCode: String,
    ) {
        executor.execute {
            var createdUri: Uri? = null
            try {
                val resolver = contentResolver
                val relativePath = Environment.DIRECTORY_DOWNLOADS + "/"
                val selection =
                    MediaStore.MediaColumns.DISPLAY_NAME + "=? AND " +
                        MediaStore.MediaColumns.RELATIVE_PATH + "=?"

                resolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    arrayOf(MediaStore.MediaColumns._ID),
                    selection,
                    arrayOf(filename, relativePath),
                    null,
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        val oldUri = Uri.withAppendedPath(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            id.toString(),
                        )
                        resolver.delete(oldUri, null, null)
                    }
                }

                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }

                val outputUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("MediaStore insert returned null.")
                createdUri = outputUri

                resolver.openOutputStream(outputUri, "w")?.use { output ->
                    output.write(content.toByteArray(StandardCharsets.UTF_8))
                    output.flush()
                } ?: throw IllegalStateException("Unable to open $filename.")

                val publish = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                resolver.update(outputUri, publish, null, null)

                val response = hashMapOf<String, Any>(
                    "success" to true,
                    "filename" to filename,
                    "uri" to outputUri.toString(),
                )
                runOnUiThread { result.success(response) }
            } catch (error: Throwable) {
                createdUri?.let {
                    try {
                        contentResolver.delete(it, null, null)
                    } catch (_: Throwable) {
                    }
                }
                runOnUiThread {
                    result.error(errorCode, messageOf(error), null)
                }
            }
        }
    }

    private fun importBackup(result: MethodChannel.Result) {
        if (pendingBackupImportResult != null) {
            result.error("BACKUP_IMPORT_PENDING", "A backup import is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }
        try {
            pendingBackupImportResult = result
            startActivityForResult(intent, BACKUP_IMPORT_REQUEST_CODE)
        } catch (error: Throwable) {
            pendingBackupImportResult = null
            result.error("BACKUP_IMPORT_PICKER_ERROR", messageOf(error), null)
        }
    }

    @Deprecated("Deprecated in Android, retained for compatibility with the existing picker flow.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != BACKUP_IMPORT_REQUEST_CODE || pendingBackupImportResult == null) return

        val result = pendingBackupImportResult
        pendingBackupImportResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result?.success(null)
            return
        }

        executor.execute {
            try {
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Unable to open the selected backup file.")
                val content = input.use { stream ->
                    ByteArrayOutputStream().use { output ->
                        val buffer = ByteArray(8192)
                        var total = 0
                        while (true) {
                            val read = stream.read(buffer)
                            if (read == -1) break
                            total += read
                            if (total > MAX_BACKUP_BYTES) {
                                throw IllegalStateException("Backup exceeds the 512 KiB size limit.")
                            }
                            output.write(buffer, 0, read)
                        }
                        String(output.toByteArray(), StandardCharsets.UTF_8)
                    }
                }
                runOnUiThread { result?.success(content) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result?.error("BACKUP_IMPORT_READ_ERROR", messageOf(error), null)
                }
            }
        }
    }

    private fun messageOf(error: Throwable): String {
        val message = error.message
        return if (message.isNullOrEmpty()) error.javaClass.simpleName else message
    }

    override fun onDestroy() {
        try {
            Shizuku.removeRequestPermissionResultListener(permissionListener)
        } catch (_: Throwable) {
        }

        executor.shutdownNow()

        try {
            val args = Shizuku.UserServiceArgs(
                ComponentName(packageName, CommandUserService::class.java.name),
            )
                .version(2)
                .tag("commands")
                .daemon(false)
                .processNameSuffix("commands")
            Shizuku.unbindUserService(args, connection, true)
        } catch (_: Throwable) {
        }

        super.onDestroy()
    }
}
