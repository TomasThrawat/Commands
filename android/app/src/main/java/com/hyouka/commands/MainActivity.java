package com.hyouka.commands;

import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.IBinder;
import android.os.RemoteException;
import android.provider.MediaStore;

import androidx.annotation.NonNull;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;
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
    private static final String SHIZUKU_PACKAGE = "moe.shizuku.privileged.api";
    private static final String OUTPUT_RELATIVE_PATH =
            Environment.DIRECTORY_DOWNLOADS + "/Commands/";

    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final ArrayDeque<Runnable> pendingActions = new ArrayDeque<>();

    private ICommandService userService;
    private boolean binding;
    private MethodChannel.Result pendingCommandResult;
    private String pendingCommand;
    private long pendingTimeout;
    private MethodChannel.Result pendingPermissionResult;

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
            case "openShizuku":
                openShizuku(result);
                break;
            case "runCommand":
                Number timeout = call.argument("timeoutMs");
                runCommand(
                        call.argument("command"),
                        timeout == null ? 120000L : timeout.longValue(),
                        result
                );
                break;
            case "saveOutput":
                saveOutput(call.argument("content"), result);
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

    private void openShizuku(MethodChannel.Result result) {
        try {
            if (!isInstalled()) {
                result.error(
                        "SHIZUKU_NOT_INSTALLED",
                        "Shizuku is not installed.",
                        null
                );
                return;
            }

            Intent intent = getPackageManager()
                    .getLaunchIntentForPackage(SHIZUKU_PACKAGE);

            if (intent == null) {
                result.error(
                        "SHIZUKU_LAUNCH_ERROR",
                        "Unable to open Shizuku.",
                        null
                );
                return;
            }

            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
            result.success(true);
        } catch (Throwable e) {
            result.error(
                    "SHIZUKU_LAUNCH_ERROR",
                    messageOf(e),
                    null
            );
        }
    }

    private void runCommand(
            String command,
            long timeoutMs,
            MethodChannel.Result result
    ) {
        if (command == null || command.trim().isEmpty()) {
            result.error("EMPTY_COMMAND", "Enter a shell command first.", null);
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
        pendingTimeout = Math.max(1000L, Math.min(timeoutMs, 120000L));
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
                    .version(1)
                    .tag("commands")
                    .daemon(false)
                    .processNameSuffix("commands");

            Shizuku.bindUserService(args, connection);
        } catch (Throwable e) {
            binding = false;
            pendingActions.clear();
            pendingCommandResult = null;
            result.error("USER_SERVICE_BIND_ERROR", messageOf(e), null);
        }
    }

    private void executePending() {
        final ICommandService service = userService;
        final MethodChannel.Result result = pendingCommandResult;
        final String command = pendingCommand;
        final long timeout = pendingTimeout;

        pendingCommandResult = null;
        pendingCommand = null;

        if (service == null || result == null || command == null) {
            return;
        }

        executor.execute(() -> {
            try {
                Bundle bundle = service.execute(command, timeout);
                Map<String, Object> output = new HashMap<>();
                output.put("stdout", bundle.getString("stdout", ""));
                output.put("stderr", bundle.getString("stderr", ""));
                output.put("exitCode", bundle.getInt("exitCode", -1));
                output.put("timedOut", bundle.getBoolean("timedOut", false));
                runOnUiThread(() -> result.success(output));
            } catch (RemoteException e) {
                userService = null;
                runOnUiThread(() ->
                        result.error("USER_SERVICE_EXECUTE_ERROR", messageOf(e), null));
            } catch (Throwable e) {
                runOnUiThread(() ->
                        result.error("COMMAND_PROCESS_ERROR", messageOf(e), null));
            }
        });
    }

    private void saveOutput(String content, MethodChannel.Result result) {
        if (content == null || content.isEmpty()) {
            result.error("SAVE_EMPTY", "There is no output to save.", null);
            return;
        }

        executor.execute(() -> {
            try {
                ContentResolver resolver = getContentResolver();

                String selection =
                        MediaStore.MediaColumns.DISPLAY_NAME + "=? AND "
                                + MediaStore.MediaColumns.RELATIVE_PATH + "=?";
                String[] args = {
                    "commands.txt",
                    OUTPUT_RELATIVE_PATH
                };

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
                values.put(
                        MediaStore.MediaColumns.DISPLAY_NAME,
                        "commands.txt"
                );
                values.put(
                        MediaStore.MediaColumns.MIME_TYPE,
                        "text/plain"
                );
                values.put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        OUTPUT_RELATIVE_PATH
                );
                values.put(
                        MediaStore.MediaColumns.IS_PENDING,
                        1
                );

                Uri uri = resolver.insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        values
                );

                if (uri == null) {
                    throw new IllegalStateException(
                            "MediaStore insert returned null."
                    );
                }

                try (OutputStream output =
                             resolver.openOutputStream(uri, "w")) {
                    if (output == null) {
                        throw new IllegalStateException(
                                "Unable to open commands.txt."
                        );
                    }
                    output.write(content.getBytes(StandardCharsets.UTF_8));
                    output.flush();
                }

                ContentValues publish = new ContentValues();
                publish.put(
                        MediaStore.MediaColumns.IS_PENDING,
                        0
                );
                resolver.update(uri, publish, null, null);

                Map<String, Object> response = new HashMap<>();
                response.put("success", true);
                response.put("filename", "commands.txt");
                response.put("relativePath", OUTPUT_RELATIVE_PATH);
                response.put("uri", uri.toString());

                runOnUiThread(() -> result.success(response));
            } catch (Throwable e) {
                runOnUiThread(() ->
                        result.error(
                                "SAVE_OUTPUT_ERROR",
                                messageOf(e),
                                null
                        ));
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
                    .version(1)
                    .tag("commands")
                    .daemon(false)
                    .processNameSuffix("commands");

            Shizuku.unbindUserService(args, connection, true);
        } catch (Throwable ignored) {
        }

        super.onDestroy();
    }
}
