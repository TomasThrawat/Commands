package com.hyouka.commands;

import android.os.Bundle;

interface ICommandService {
    Bundle execute(String command, long commandId);
    boolean cancel(long commandId);
    void destroy();
}
