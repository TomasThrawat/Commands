package com.hyouka.commands;

import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.IBinder;
import android.os.RemoteException;
import android.provider.MediaStore;

import androidx.annotation.NonNull;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import rikka.shizuku.Shizuku;

public final class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.hyouka.commands/shizuku";
    private static final int REQUEST_CODE = 4401;
    private static final int BACKUP_IMPORT_REQUEST_CODE = 4402;
    private static final String PREFERENCES_NAME = "commands_app_preferences";
    private static final int MAX_BACKUP_BYTES = 512 * 1024;
    private static final String SHIZUKU_PACKAGE = "moe.shizuku.privileged.api";

    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final ArrayDeque<Runnable> pendingActions = new ArrayDeque<>();

    private ICommandService userService;
    private boolean binding;
    private MethodChannel.Result pendingCommandResult;
    private String pendingCommand;
    private long pendingCommandId = -1L;
    private volatile long activeCommandId = -1L;
    private final Set<Long> pendingCancellations = ConcurrentHashMap.newKeySet();
    private MethodChannel.Result pendingPermissionResult;
    private MethodChannel.Result pendingBackupImportResult;

    private final Shizuku.OnRequestPermissionResultListener permissionListener =
            (requestCode, grantResult) -> {
                if (requestCode != REQUEST_CODE || pendingPermissionResult == null) {
                    return;
                }
                MethodChannel.Result result = pendingPermissionResult;
                pendingPermissionResult = null;
                runOnUiThread(() ->
                        result.success(grantResult == PackageManager.PERMISSION_GRANTED));
            };

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
            userService = ICommandService.Stub.asInterface(service);
            binding = false;
            while (!pendingActions.isEmpty()) {
                pendingActions.removeFirst().run();
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            userService = null;
            binding = false;
        }
    };

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        MethodChannel channel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                CHANNEL
        );
        channel.setMethodCallHandler(this::handleCall);

        Shizuku.addRequestPermissionResultListener(permissionListener);
    }

    private void handleCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "status":
                result.success(status());
                break;
            case "requestPermission":
                requestPermission(result);
                break;
            case "runCommand":
                Number commandId = call.argument("commandId");
                if (commandId == null) {
                    result.error("INVALID_COMMAND_ID", "Missing command ID.", null);
                    break;
                }
                runCommand(call.argument("command"), commandId.longValue(), result);
                break;
            case "cancelCommand":
                Number cancelId = call.argument("commandId");
                if (cancelId == null) {
                    result.error("INVALID_COMMAND_ID", "Missing command ID.", null);
                    break;
                }
                cancelCommand(cancelId.longValue(), result);
                break;
            case "saveOutput":
                saveOutput(call.argument("content"), result);
                break;
            case "loadPreferences":
                result.success(loadPreferences());
                break;
            case "savePreferences":
                savePreferences(call, result);
                break;
            case "exportBackup":
                exportBackup(call.argument("content"), result);
                break;
            case "importBackup":
                importBackup(result);
                break;
            default:
                result.notImplemented();
        }
    }

    private Map<String, Object> status() {
        boolean installed = isInstalled();
        boolean running = false;
        boolean permission = false;

        try {
            running = Shizuku.pingBinder();
            if (running) {
                permission =
                        Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
            }
        } catch (Throwable ignored) {
        }

        Map<String, Object> result = new HashMap<>();
        result.put("installed", installed);
        result.put("running", running);
        result.put("permission", permission);
        result.put("serviceConnected", userService != null);
        result.put("binding", binding);
        return result;
    }

    private boolean isInstalled() {
        try {
            getPackageManager().getApplicationInfo(SHIZUKU_PACKAGE, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private boolean authorized() {
        try {
            return Shizuku.pingBinder()
                    && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private void requestPermission(MethodChannel.Result result) {
        try {
            if (!isInstalled()) {
                result.error("SHIZUKU_NOT_INSTALLED", "Shizuku is not installed.", null);
                return;
            }
            if (!Shizuku.pingBinder()) {
                result.error("SHIZUKU_NOT_RUNNING", "Shizuku is not running.", null);
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                result.success(true);
                return;
            }
            if (pendingPermissionResult != null) {
                result.error(
                        "PERMISSION_REQUEST_PENDING",
                        "A permission request is already pending.",
                        null
                );
                return;
            }
            pendingPermissionResult = result;
            Shizuku.requestPermission(REQUEST_CODE);
        } catch (Throwable e) {
            pendingPermissionResult = null;
            result.error("SHIZUKU_PERMISSION_ERROR", messageOf(e), null);
        }
    }

    private void runCommand(String command, long commandId, MethodChannel.Result result) {
        if (command == null || command.trim().isEmpty()) {
            result.error("EMPTY_COMMAND", "Enter a shell command first.", null);
            return;
        }
        if (commandId <= 0L) {
            result.error("INVALID_COMMAND_ID", "Invalid command ID.", null);
            return;
        }
        if (pendingCommandResult != null || activeCommandId != -1L) {
            result.error("COMMAND_BUSY", "A command is already running.", null);
            return;
        }

        if (!authorized()) {
            result.error(
                    "SHIZUKU_PERMISSION_REQUIRED",
                    "Shizuku is not installed, not running, or not authorized.",
                    status()
            );
            return;
        }

        pendingCommand = command;
        pendingCommandId = commandId;
        pendingCommandResult = result;

        if (userService != null) {
            executePending();
            return;
        }

        if (binding) {
            return;
        }

        binding = true;
        pendingActions.add(this::executePending);

        try {
            Shizuku.UserServiceArgs args = new Shizuku.UserServiceArgs(
                    new ComponentName(getPackageName(), CommandUserService.class.getName())
            )
                    .version(2)
                    .tag("commands")
                    .daemon(false)
                    .processNameSuffix("commands");

            Shizuku.bindUserService(args, connection);
        } catch (Throwable e) {
            binding = false;
            pendingActions.clear();
            pendingCommandResult = null;
            pendingCommand = null;
            pendingCommandId = -1L;
            pendingCancellations.remove(commandId);
            result.error("USER_SERVICE_BIND_ERROR", messageOf(e), null);
        }
    }

    private void cancelCommand(long commandId, MethodChannel.Result result) {
        if (commandId <= 0L) {
            result.error("INVALID_COMMAND_ID", "Invalid command ID.", null);
            return;
        }

        if (pendingCommandResult != null && pendingCommandId == commandId) {
            pendingCancellations.add(commandId);
            result.success(true);
            return;
        }

        if (activeCommandId != commandId) {
            result.success(false);
            return;
        }

        final ICommandService service = userService;
        if (service == null) {
            pendingCancellations.add(commandId);
            result.success(true);
            return;
        }

        executor.execute(() -> {
            try {
                boolean cancelled = service.cancel(commandId);
                runOnUiThread(() -> result.success(cancelled));
            } catch (RemoteException e) {
                userService = null;
                runOnUiThread(() ->
                        result.error("USER_SERVICE_CANCEL_ERROR", messageOf(e), null));
            } catch (Throwable e) {
                runOnUiThread(() ->
                        result.error("COMMAND_CANCEL_ERROR", messageOf(e), null));
            }
        });
    }

    private void executePending() {
        final ICommandService service = userService;
        final MethodChannel.Result result = pendingCommandResult;
        final String command = pendingCommand;
        final long commandId = pendingCommandId;

        pendingCommandResult = null;
        pendingCommand = null;
        pendingCommandId = -1L;

        if (service == null || result == null || command == null || commandId <= 0L) {
            return;
        }

        activeCommandId = commandId;
        executor.execute(() -> {
            try {
                Map<String, Object> output = new HashMap<>();
                if (pendingCancellations.remove(commandId)) {
                    output.put("stdout", "");
                    output.put("stderr", "");
                    output.put("exitCode", -1);
                    output.put("cancelled", true);
                } else {
                    Bundle bundle = service.execute(command, commandId);
                    output.put("stdout", bundle.getString("stdout", ""));
                    output.put("stderr", bundle.getString("stderr", ""));
                    output.put("exitCode", bundle.getInt("exitCode", -1));
                    output.put("cancelled", bundle.getBoolean("cancelled", false));
                }
                runOnUiThread(() -> {
                    if (activeCommandId == commandId) {
                        activeCommandId = -1L;
                    }
                    result.success(output);
                });
            } catch (RemoteException e) {
                userService = null;
                runOnUiThread(() -> {
                    if (activeCommandId == commandId) {
                        activeCommandId = -1L;
                    }
                    result.error("USER_SERVICE_EXECUTE_ERROR", messageOf(e), null);
                });
            } catch (Throwable e) {
                runOnUiThread(() -> {
                    if (activeCommandId == commandId) {
                        activeCommandId = -1L;
                    }
                    result.error("COMMAND_PROCESS_ERROR", messageOf(e), null);
                });
            }
        });
    }

    private Map<String, Object> loadPreferences() {
        SharedPreferences preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE);
        Map<String, Object> values = new HashMap<>();
        values.put("themeMode", preferences.getString("themeMode", "dark"));
        values.put("fontScale", Float.valueOf(preferences.getFloat("fontScale", 1.0f)));
        values.put("lastCommand", preferences.getString("lastCommand", ""));
        values.put("historyJson", preferences.getString("historyJson", "[]"));
        values.put("changesJson", preferences.getString("changesJson", "[]"));
        return values;
    }

    private void savePreferences(MethodCall call, MethodChannel.Result result) {
        String themeMode = call.argument("themeMode");
        Number fontScale = call.argument("fontScale");
        String lastCommand = call.argument("lastCommand");
        String historyJson = call.argument("historyJson");
        String changesJson = call.argument("changesJson");

        if (!("dark".equals(themeMode) || "light".equals(themeMode) || "system".equals(themeMode))) {
            result.error("INVALID_PREFERENCES", "Unsupported appearance value.", null);
            return;
        }
        if (fontScale == null || !Float.isFinite(fontScale.floatValue())
                || fontScale.floatValue() < 0.85f || fontScale.floatValue() > 1.4f) {
            result.error("INVALID_PREFERENCES", "Text scale is outside the supported range.", null);
            return;
        }
        if (lastCommand == null || lastCommand.length() > 4096
                || historyJson == null || historyJson.length() > 300000
                || changesJson == null || changesJson.length() > 100000) {
            result.error("INVALID_PREFERENCES", "Preference data is too large or incomplete.", null);
            return;
        }

        getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
                .edit()
                .putString("themeMode", themeMode)
                .putFloat("fontScale", fontScale.floatValue())
                .putString("lastCommand", lastCommand)
                .putString("historyJson", historyJson)
                .putString("changesJson", changesJson)
                .apply();
        result.success(true);
    }

    private void saveOutput(String content, MethodChannel.Result result) {
        if (content == null) {
            result.error("SAVE_EMPTY", "There is no output to save.", null);
            return;
        }
        saveTextToDownloads(content, "commands.txt", "text/plain", result, "SAVE_OUTPUT_ERROR");
    }

    private void exportBackup(String content, MethodChannel.Result result) {
        if (content == null || content.isEmpty()) {
            result.error("BACKUP_EMPTY", "There is no backup data to export.", null);
            return;
        }
        if (content.getBytes(StandardCharsets.UTF_8).length > MAX_BACKUP_BYTES) {
            result.error("BACKUP_TOO_LARGE", "Backup exceeds the supported size limit.", null);
            return;
        }
        saveTextToDownloads(
                content,
                "commands-backup.json",
                "application/json",
                result,
                "EXPORT_BACKUP_ERROR"
        );
    }

    private void saveTextToDownloads(
            String content,
            String filename,
            String mimeType,
            MethodChannel.Result result,
            String errorCode
    ) {
        executor.execute(() -> {
            Uri createdUri = null;
            try {
                ContentResolver resolver = getContentResolver();
                String relativePath = Environment.DIRECTORY_DOWNLOADS + "/";

                String selection =
                        MediaStore.MediaColumns.DISPLAY_NAME + "=? AND "
                                + MediaStore.MediaColumns.RELATIVE_PATH + "=?";
                String[] args = {filename, relativePath};

                try (android.database.Cursor cursor = resolver.query(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        new String[]{MediaStore.MediaColumns._ID},
                        selection,
                        args,
                        null
                )) {
                    if (cursor != null) {
                        while (cursor.moveToNext()) {
                            long id = cursor.getLong(0);
                            Uri oldUri = Uri.withAppendedPath(
                                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                    Long.toString(id)
                            );
                            resolver.delete(oldUri, null, null);
                        }
                    }
                }

                ContentValues values = new ContentValues();
                values.put(MediaStore.MediaColumns.DISPLAY_NAME, filename);
                values.put(MediaStore.MediaColumns.MIME_TYPE, mimeType);
                values.put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath);
                values.put(MediaStore.MediaColumns.IS_PENDING, 1);

                createdUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                if (createdUri == null) {
                    throw new IllegalStateException("MediaStore insert returned null.");
                }

                try (OutputStream output = resolver.openOutputStream(createdUri, "w")) {
                    if (output == null) {
                        throw new IllegalStateException("Unable to open " + filename + ".");
                    }
                    output.write(content.getBytes(StandardCharsets.UTF_8));
                    output.flush();
                }

                ContentValues publish = new ContentValues();
                publish.put(MediaStore.MediaColumns.IS_PENDING, 0);
                resolver.update(createdUri, publish, null, null);

                Map<String, Object> response = new HashMap<>();
                response.put("success", true);
                response.put("filename", filename);
                response.put("uri", createdUri.toString());
                runOnUiThread(() -> result.success(response));
            } catch (Throwable e) {
                if (createdUri != null) {
                    try {
                        getContentResolver().delete(createdUri, null, null);
                    } catch (Throwable ignored) {
                    }
                }
                runOnUiThread(() -> result.error(errorCode, messageOf(e), null));
            }
        });
    }

    private void importBackup(MethodChannel.Result result) {
        if (pendingBackupImportResult != null) {
            result.error("BACKUP_IMPORT_PENDING", "A backup import is already open.", null);
            return;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/json");
        try {
            pendingBackupImportResult = result;
            startActivityForResult(intent, BACKUP_IMPORT_REQUEST_CODE);
        } catch (Throwable e) {
            pendingBackupImportResult = null;
            result.error("BACKUP_IMPORT_PICKER_ERROR", messageOf(e), null);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != BACKUP_IMPORT_REQUEST_CODE || pendingBackupImportResult == null) {
            return;
        }
        MethodChannel.Result result = pendingBackupImportResult;
        pendingBackupImportResult = null;
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            result.success(null);
            return;
        }

        Uri uri = data.getData();
        executor.execute(() -> {
            try (InputStream input = getContentResolver().openInputStream(uri);
                 ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                if (input == null) {
                    throw new IllegalStateException("Unable to open the selected backup file.");
                }
                byte[] buffer = new byte[8192];
                int read;
                int total = 0;
                while ((read = input.read(buffer)) != -1) {
                    total += read;
                    if (total > MAX_BACKUP_BYTES) {
                        throw new IllegalStateException("Backup exceeds the 512 KiB size limit.");
                    }
                    output.write(buffer, 0, read);
                }
                String content = new String(output.toByteArray(), StandardCharsets.UTF_8);
                runOnUiThread(() -> result.success(content));
            } catch (Throwable e) {
                runOnUiThread(() -> result.error("BACKUP_IMPORT_READ_ERROR", messageOf(e), null));
            }
        });
    }

    private static String messageOf(Throwable e) {
        String message = e.getMessage();
        return message == null || message.isEmpty()
                ? e.getClass().getSimpleName()
                : message;
    }

    @Override
    protected void onDestroy() {
        try {
            Shizuku.removeRequestPermissionResultListener(permissionListener);
        } catch (Throwable ignored) {
        }

        executor.shutdownNow();

        try {
            Shizuku.UserServiceArgs args = new Shizuku.UserServiceArgs(
                    new ComponentName(getPackageName(), CommandUserService.class.getName())
            )
                    .version(2)
                    .tag("commands")
                    .daemon(false)
                    .processNameSuffix("commands");

            Shizuku.unbindUserService(args, connection, true);
        } catch (Throwable ignored) {
        }

        super.onDestroy();
    }
}
