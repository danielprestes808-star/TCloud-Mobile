package com.tcloud.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class TCloudBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (
            intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        if (!TCloudBackupService.isEnabled(context)) return
        TCloudBackupService.enqueueBackup(context)
        try {
            TCloudBackupService.start(context)
        } catch (_: Throwable) {
            // Alguns Androids nao permitem iniciar FGS no boot; o Worker
            // agendado acima ainda executa e o servico inicia no proximo app.
        }
    }
}
