package com.hyouka.commands

import android.os.Bundle
import org.json.JSONObject

class CommandUserService : ICommandService.Stub() {
    override fun execute(command: String, commandId: Long): Bundle {
        require(command.isNotBlank()) { "Command is empty." }
        require(commandId > 0L) { "Invalid command ID." }

        val payload = JSONObject(nativeExecute(command, commandId))
        if (payload.has("error")) {
            throw IllegalStateException(payload.optString("error", "Command execution failed."))
        }

        return Bundle().apply {
            putString("stdout", payload.optString("stdout", ""))
            putString("stderr", payload.optString("stderr", ""))
            putInt("exitCode", payload.optInt("exitCode", -1))
            putBoolean("cancelled", payload.optBoolean("cancelled", false))
        }
    }

    override fun cancel(commandId: Long): Boolean = nativeCancel(commandId)

    override fun destroy() {
        nativeDestroy()
        System.exit(0)
    }

    companion object {
        init {
            System.loadLibrary("commands_engine")
        }

        @JvmStatic
        private external fun nativeExecute(command: String, commandId: Long): String

        @JvmStatic
        private external fun nativeCancel(commandId: Long): Boolean

        @JvmStatic
        private external fun nativeDestroy()
    }
}
