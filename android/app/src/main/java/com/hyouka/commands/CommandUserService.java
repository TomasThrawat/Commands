package com.hyouka.commands;

import android.os.Bundle;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

public final class CommandUserService extends ICommandService.Stub {
    private static final int MAX_OUTPUT_BYTES = 256 * 1024;

    public CommandUserService() {
        super();
    }

    @Override
    public Bundle execute(String command, long timeoutMs) {
        if (command == null || command.trim().isEmpty()) {
            throw new IllegalArgumentException("Command is empty.");
        }

        final long timeout = Math.max(1000L, Math.min(timeoutMs, 120000L));
        Process process = null;
        Collector out = null;
        Collector err = null;
        boolean timedOut = false;

        try {
            process = new ProcessBuilder("sh", "-c", command)
                    .redirectErrorStream(false)
                    .start();

            out = new Collector(process.getInputStream());
            err = new Collector(process.getErrorStream());

            Thread outThread = new Thread(out, "commands-stdout");
            Thread errThread = new Thread(err, "commands-stderr");
            outThread.start();
            errThread.start();

            boolean finished = process.waitFor(timeout, TimeUnit.MILLISECONDS);
            if (!finished) {
                timedOut = true;
                process.destroy();
                if (!process.waitFor(750L, TimeUnit.MILLISECONDS)) {
                    process.destroyForcibly();
                }
            }

            outThread.join(2000L);
            errThread.join(2000L);

            Bundle result = new Bundle();
            result.putString("stdout", out.snapshot());
            result.putString("stderr", err.snapshot());
            result.putInt("exitCode", finished ? process.exitValue() : -1);
            result.putBoolean("timedOut", timedOut);
            return result;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Command execution was interrupted.", e);
        } catch (Exception e) {
            String message = e.getMessage();
            throw new IllegalStateException(
                    message == null ? e.getClass().getSimpleName() : message,
                    e
            );
        } finally {
            if (process != null) {
                try { process.getInputStream().close(); } catch (Exception ignored) {}
                try { process.getErrorStream().close(); } catch (Exception ignored) {}
                try { process.getOutputStream().close(); } catch (Exception ignored) {}
                process.destroy();
            }
        }
    }

    @Override
    public void destroy() {
        System.exit(0);
    }

    private static final class Collector implements Runnable {
        private final InputStream input;
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private boolean truncated;

        Collector(InputStream input) {
            this.input = input;
        }

        @Override
        public void run() {
            byte[] buffer = new byte[8192];
            int read;

            try {
                while ((read = input.read(buffer)) != -1) {
                    synchronized (bytes) {
                        int remaining = MAX_OUTPUT_BYTES - bytes.size();
                        if (remaining > 0) {
                            bytes.write(buffer, 0, Math.min(read, remaining));
                        }
                        if (read > remaining) {
                            truncated = true;
                        }
                    }
                }
            } catch (Exception ignored) {
            }
        }

        String snapshot() {
            synchronized (bytes) {
                String value = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
                return truncated ? value + "\n[output truncated at 256 KiB]" : value;
            }
        }
    }
}
