package com.hyouka.commands;

import android.os.Bundle;

interface ICommandService {
    Bundle execute(String command, long timeoutMs);
    void destroy();
}
