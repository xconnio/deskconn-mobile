package io.xconn.deskconn

import android.app.Service
import android.content.Intent
import android.os.IBinder

class TaskRemovedService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        started = true
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // A process killed while this service is started counts as a crashed service, so Android
        // restarts it and redelivers this callback into the next launch, which then kills itself.
        // Stop first so no restart is scheduled, and ignore a callback that wasn't ours to begin with.
        val wasStarted = started
        started = false
        stopSelf()
        if (wasStarted) AppShutdown.shutdown(applicationContext)
    }

    companion object {
        // Only set once MainActivity starts the service in this process.
        @Volatile private var started = false
    }
}
